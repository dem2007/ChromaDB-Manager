import Foundation

/// Что предложить человеку, когда на приложение перетащили файлы или папки
///, а также что делать с ними из «Служб» Finder.
///
/// Правила отдельно от интерфейса: «папка — это источник, файл — это
/// документ» — решение, а не отрисовка, и проверять его надо тестом.
public struct DroppedItems: Equatable, Sendable {
    /// Папки: их предлагается зарегистрировать источниками.
    public let folders: [URL]
    /// Файлы, из которых приложение умеет извлекать текст.
    public let files: [URL]
    /// Файлы, которые извлечение не берёт, — их называют вслух, а не
    /// молча выбрасывают: человек перетащил их намеренно.
    public let unsupported: [URL]

    public init(folders: [URL], files: [URL], unsupported: [URL]) {
        self.folders = folders
        self.files = files
        self.unsupported = unsupported
    }

    public var isEmpty: Bool { folders.isEmpty && files.isEmpty && unsupported.isEmpty }

    /// Есть ли что предложить сделать. Одни неподдержанные файлы — это
    /// «нечего делать», и предлагать выбор в этом случае нельзя.
    public var hasSomethingToDo: Bool { !folders.isEmpty || !files.isEmpty }

    /// Разбирает то, что бросили.
    ///
    /// «Умеем ли прочитать» — это ровно тот список расширений, который
    /// приложение ставит новому источнику: обещать взять файл, который
    /// синхронизация потом пропустит, нельзя. Реестр извлечения для этого
    /// не годится — таблицы идут не через него.
    public static func classify(
        _ urls: [URL],
        canExtract: (URL) -> Bool = { url in
            TextExtractor.supportedExtensions.contains(url.pathExtension.lowercased())
        },
        isDirectory: (URL) -> Bool = { url in
            var flag: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &flag)
            return exists && flag.boolValue
        }
    ) -> DroppedItems {
        var folders: [URL] = []
        var files: [URL] = []
        var unsupported: [URL] = []
        // Порядок сохраняется: человек бросил их в каком-то порядке, и
        // список в диалоге должен совпадать с тем, что он видел.
        for url in urls {
            if isDirectory(url) {
                folders.append(url)
            } else if canExtract(url) {
                files.append(url)
            } else {
                unsupported.append(url)
            }
        }
        return DroppedItems(folders: folders, files: files, unsupported: unsupported)
    }

    /// Строка для диалога: что именно бросили.
    public var summary: String {
        var parts: [String] = []
        if !folders.isEmpty {
            parts.append(RussianCount.grouped(folders.count, "папка", "папки", "папок"))
        }
        if !files.isEmpty {
            parts.append(RussianCount.grouped(files.count, "файл", "файла", "файлов"))
        }
        if !unsupported.isEmpty {
            parts.append(String(localized: "не читается: \(RussianCount.grouped(unsupported.count, "файл", "файла", "файлов"))"))
        }
        return parts.isEmpty ? String(localized: "ничего") : parts.joined(separator: ", ")
    }
}
