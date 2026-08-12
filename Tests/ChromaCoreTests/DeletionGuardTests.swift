import XCTest
@testable import ChromaCore

/// Правила 1 и 5 приложения 5 и J3 — в виде сторожа по исходникам.
///
/// Те же соображения, что у `NoQueueBypassTests`: правила эти — про то, как
/// написан код, а не про то, что он вычисляет. Экран, удаляющий документ мимо
/// корзины, скомпилируется, пройдёт все прочие тесты и молча заберёт у человека
/// единственную возможность передумать. Такое ловится только чтением исходников.
final class DeletionGuardTests: XCTestCase {
    private var appSources: [URL] {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/ChromaDBManagerApp")
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                throw XCTSkip("исходники приложения не найдены рядом с тестами")
            }
            return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
    }

    /// Строки объемлющей функции: от её объявления до строки вызова.
    ///
    /// Границей считается `func` с отступом не глубже метода типа — вложенные
    /// замыкания её не сбивают, а вот соседний метод отсекает, и находка из
    /// одного метода не зачтётся другому.
    static func enclosingFunction(of index: Int, in lines: [String]) -> ArraySlice<String> {
        var start = index
        while start > 0 {
            let line = lines[start]
            let indent = line.prefix { $0 == " " }.count
            if indent <= 4, line.contains("func ") { break }
            start -= 1
        }
        return lines[start...index]
    }

    /// J3 и правило 1: ручное удаление обратимо — копия уходит в корзину.
    ///
    /// Проверяется весь слой приложения: и документы, и коллекция целиком.
    /// Удаление внутри синхронизации («прочитать → записать → удалить
    /// старое явным списком») живёт в ядре и сюда не попадает — там удаляются
    /// заменённые чанки, а не то, что человек может захотеть вернуть.
    func testEveryManualDeletionGoesThroughTheTrash() throws {
        let deletions = ["deleteDocuments(", "deleteCollection("]
        var offenders: [String] = []

        for file in try appSources {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                guard deletions.contains(where: { code.contains($0) }), !code.contains("func ") else { continue }
                let body = Self.enclosingFunction(of: index, in: lines).joined(separator: "\n")
                let savesFirst = body.contains("trash.record(") || body.contains("captureCollectionToTrash(")
                if !savesFirst {
                    offenders.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            Ручное удаление обязано быть обратимым (правило 1 приложения 5): \
            перед удалением копия уходит в корзину. Найдено удаление без копии:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// Правило 5: разрушительная операция начинается с резервной копии.
    ///
    /// Здесь это держится не соглашением, а подписью: `ReembeddingService.run`
    /// принимает `BackupEvidence` — доказательство, которое выдаёт только тот,
    /// кто копию снял. Тест сторожит саму подпись: убрать из неё аргумент —
    /// значит убрать правило.
    func testTheDestructiveRunCannotBeCalledWithoutABackup() throws {
        let service = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaCore/Services/ReembeddingService.swift")
        let text = try String(contentsOf: service, encoding: .utf8)
        guard let signature = text.range(of: "func run(") else {
            return XCTFail("не найдена точка входа пересчёта")
        }
        let head = String(text[signature.lowerBound...].prefix(600))
        XCTAssertTrue(
            head.contains("backup: BackupEvidence"),
            "Пересчёт обязан принимать доказательство копии (правило 5 приложения 5): \(head.prefix(200))"
        )
    }

    /// Правило 3: кнопка-корзина у источника спрашивает, а не удаляет.
    ///
    /// Она стоит вплотную к «Синхронизировать», а промах стоит всей настройки
    /// источника: стратегию можно поднять из манифеста, а расписания, поля
    /// метаданных, профили таблиц и параметры нарезки — уже ниоткуда. Ровно
    /// это выяснилось при восстановлении одиннадцати источников 9 августа
    /// 2026 года.
    func testRemovingASourceAsksFirst() throws {
        let view = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views/SourcesView.swift")
        let text = try String(contentsOf: view, encoding: .utf8)

        XCTAssertTrue(
            text.contains("confirmationDialog"),
            "удаление источника обязано спрашивать (правило 3 приложения 5)"
        )
        // Кнопка только помечает намерение; само удаление живёт в диалоге.
        // Она переехала из ряда действий в меню «…» карточки источника
        // — ищется по своей надписи, а не по иконке корзины.
        let lines = text.components(separatedBy: .newlines)
        guard let remove = lines.firstIndex(where: { $0.contains("Убрать источник из списка") }) else {
            return XCTFail("кнопка удаления источника не найдена — тест устарел")
        }
        let action = lines[remove...min(lines.count - 1, remove + 6)].joined(separator: "\n")
        XCTAssertFalse(
            action.contains("removeSource("),
            "кнопка не должна удалять сама:\n\(action)"
        )
        XCTAssertTrue(action.contains("sourcePendingRemoval"), action)

        // И человек должен прочитать, что именно исчезает, а что остаётся:
        // «удалить источник?» без этого читается как «удалить коллекцию?».
        XCTAssertTrue(text.contains("останутся нетронутыми"), "в вопросе сказано, что уцелеет")
        XCTAssertTrue(text.contains("восстановить их будет неоткуда"), "и что пропадёт навсегда")
    }

    /// Сторож бесполезен, если читает пустоту.
    func testTheGuardActuallyReadsTheSources() throws {
        let files = try appSources
        XCTAssertGreaterThan(files.count, 15)
        let text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(text.contains("deleteDocuments("), "в приложении должны быть удаления")
        XCTAssertTrue(text.contains("trash.record("), "и запись в корзину")
    }

    /// А ещё — что он умеет отличать метод от соседнего.
    func testTheFunctionBoundaryIsNotFooledByNeighbours() {
        let lines = """
            func saves() {
                app.trash.record(entry)
                try await client.deleteDocuments(ids: ids)
            }

            func doesNot() {
                try await client.deleteDocuments(ids: ids)
            }
        """.components(separatedBy: "\n")
        XCTAssertTrue(Self.enclosingFunction(of: 2, in: lines).joined().contains("trash.record("))
        XCTAssertFalse(Self.enclosingFunction(of: 6, in: lines).joined().contains("trash.record("))
    }
}
