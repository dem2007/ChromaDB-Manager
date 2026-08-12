import XCTest

/// Сторож окружения сцен.
///
/// `@EnvironmentObject`, которого нет в окружении, — не пустое значение, а
/// **падение** при первом обращении к нему, и падает только та сцена, где
/// объект забыли. Так и случилось: очередь переехала в `QueueMirror`, меню
/// строки меню стало её читать, а окружение своей сцены не получило — клик по
/// значку ронял приложение, пока главное окно работало как ни в чём не бывало.
///
/// Глазами это не проверяется: сцен четыре, объектов девять, а увидеть пропажу
/// можно только в той сцене, которую догадались открыть. Поэтому проверяет
/// тест: каждый тип, который экраны просят у окружения, обязан быть в общем
/// списке `chromaEnvironment`.
final class EnvironmentInjectionTests: XCTestCase {
    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp")
    }

    /// Типы, которые виды просят через `@EnvironmentObject`.
    private func requestedTypes() throws -> Set<String> {
        var found: Set<String> = []
        for file in try swiftFiles(in: sources) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: .newlines) {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard code.hasPrefix("@EnvironmentObject") else { continue }
                guard let colon = code.lastIndex(of: ":") else { continue }
                let type = code[code.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: CharacterSet(charactersIn: " ?="))[0]
                if !type.isEmpty { found.insert(type) }
            }
        }
        return found
    }

    /// Типы, которые кладёт общий модификатор. Читаются по именам свойств
    /// `AppEnvironment`, чтобы список нельзя было «пополнить» комментарием.
    private func injectedTypes() throws -> Set<String> {
        let environmentFile = sources.appendingPathComponent("ViewModels/AppEnvironment.swift")
        let text = try String(contentsOf: environmentFile, encoding: .utf8)
        guard let range = text.range(of: "func chromaEnvironment(") else {
            XCTFail("chromaEnvironment не найден — окружение сцен собирается вручную")
            return []
        }
        let body = text[range.upperBound...]

        var injected: Set<String> = []
        for line in body.components(separatedBy: .newlines) {
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("}") && !code.contains("environmentObject") { break }
            guard code.hasPrefix(".environmentObject(") else { continue }
            let argument = code
                .replacingOccurrences(of: ".environmentObject(", with: "")
                .replacingOccurrences(of: ")", with: "")
            // `app` — сам AppEnvironment, остальное — его свойства.
            if argument == "app" {
                injected.insert("AppEnvironment")
            } else if let property = argument.split(separator: ".").last {
                injected.insert(try typeOfProperty(String(property), in: text))
            }
        }
        return injected
    }

    /// Тип свойства `AppEnvironment` по его объявлению.
    private func typeOfProperty(_ name: String, in text: String) throws -> String {
        for line in text.components(separatedBy: .newlines) {
            let code = line.trimmingCharacters(in: .whitespaces)
            guard code.hasPrefix("let \(name):") || code.hasPrefix("let \(name) =") else { continue }
            if let colon = code.firstIndex(of: ":") {
                return code[code.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: CharacterSet(charactersIn: " ?="))[0]
            }
            // `let queueMirror = QueueMirror()` — тип выводится из значения.
            if let equals = code.firstIndex(of: "=") {
                return code[code.index(after: equals)...]
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: "(")[0]
            }
        }
        return name
    }

    func testEveryEnvironmentObjectScreensAskForIsInjected() throws {
        let requested = try requestedTypes()
        let injected = try injectedTypes()
        XCTAssertFalse(requested.isEmpty, "не нашлось ни одного @EnvironmentObject — сломался разбор")

        let missing = requested.subtracting(injected).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            """
            Эти объекты экраны просят у окружения, но `chromaEnvironment` их не кладёт.
            В сцене, где такой объект понадобится, приложение упадёт при первом
            обращении к нему — как упало меню строки меню на QueueMirror:
            \(missing.joined(separator: ", "))
            """
        )
    }

    /// Сцены не собирают окружение вручную: иначе общий список ничего не
    /// гарантирует — он просто ещё одно место, о котором можно забыть.
    func testScenesUseTheSharedEnvironmentModifier() throws {
        let allowed = ["AppEnvironment.swift"]
        var offences: [String] = []
        for file in try swiftFiles(in: sources) where !allowed.contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.components(separatedBy: .newlines).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard code.hasPrefix(".environmentObject(") else { continue }
                offences.append("\(file.lastPathComponent):\(number + 1): \(code)")
            }
        }
        XCTAssertTrue(
            offences.isEmpty,
            """
            Окружение сцены собирается вручную вместо `chromaEnvironment(app)`:
            \(offences.joined(separator: "\n"))
            """
        )
    }


    /// Каждая сцена доводит окружение до своего корня.
    ///
    /// Двух проверок выше не хватало: они следят за **составом** общего списка
    /// и за тем, что его не собирают вручную, — но ни одна не спрашивала,
    /// применяет ли сцена `chromaEnvironment` вообще. Сцена, забывшая
    /// модификатор целиком, проходила обе и падала при первом же обращении
    /// к окружению — тем самым `EXC_BREAKPOINT` в `MenuBarView.summary`,
    /// ради которого всё это и заводилось.
    ///
    /// Проверяются места, куда окружение **не наследуется**: сцены `Window`,
    /// `WindowGroup`, `MenuBarExtra` и всё, что вешается на `NSHostingView`
    /// и `NSHostingController`. Лист или всплывающее окно внутри вида
    /// окружение наследует, и требовать модификатор от них незачем.
    func testEverySceneRootCarriesTheEnvironment() throws {
        var offences: [String] = []

        for file in try swiftFiles(in: sources) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let lines = text.components(separatedBy: .newlines)

            for (number, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                let isScene = code.hasPrefix("Window(") || code.hasPrefix("WindowGroup(")
                    || code.hasPrefix("MenuBarExtra(")
                let isHosting = code.contains("NSHostingView(rootView:")
                    || code.contains("NSHostingController(rootView:")
                guard isScene || isHosting else { continue }

                // У `NSHostingView` корень обычно собирают переменной выше по
                // функции, поэтому смотреть вперёд бессмысленно — спрашиваем
                // с файла целиком.
                if isHosting {
                    if !text.contains(".chromaEnvironment(") {
                        offences.append("\(file.lastPathComponent):\(number + 1): \(code)")
                    }
                    continue
                }

                // Корень сцены — либо сам применяет модификатор поблизости,
                // либо это вид, который применяет его у себя.
                let window = lines[number..<min(number + 14, lines.count)].joined(separator: "\n")
                if window.contains(".chromaEnvironment(") { continue }
                if let root = Self.rootViewType(in: window),
                   try declaringFileApplies(root) { continue }

                offences.append("\(file.lastPathComponent):\(number + 1): \(code)")
            }
        }

        XCTAssertTrue(
            offences.isEmpty,
            """
            Эти корни сцен не доводят окружение — приложение упадёт при первом
            обращении к любому @EnvironmentObject внутри них:
            \(offences.joined(separator: "\n"))
            """
        )
    }

    /// Имя вида, который поставлен корнем: первое `ИмяТипа(` с заглавной буквы
    /// после объявления сцены.
    private static func rootViewType(in text: String) -> String? {
        let skipped: Set<String> = [
            "Window", "WindowGroup", "MenuBarExtra", "NSHostingView", "NSHostingController",
            "String", "Image", "Binding", "Text",
        ]
        for line in text.components(separatedBy: .newlines).dropFirst() {
            let code = line.trimmingCharacters(in: .whitespaces)
            guard let match = code.range(of: "\\b[A-Z][A-Za-z0-9_]*\\(", options: .regularExpression) else { continue }
            let name = String(code[match].dropLast())
            if skipped.contains(name) { continue }
            return name
        }
        return nil
    }

    /// Применяет ли файл, объявляющий этот вид, общий модификатор.
    private func declaringFileApplies(_ type: String) throws -> Bool {
        for file in try swiftFiles(in: sources) {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("struct \(type): View") || text.contains("struct \(type) : View") else { continue }
            return text.contains(".chromaEnvironment(")
        }
        return false
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
