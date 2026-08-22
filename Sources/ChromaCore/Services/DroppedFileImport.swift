import Foundation

/// Подготовка перетащенных файлов к добавлению документами.
///
/// Разовое добавление файла — это **один документ на файл**, без нарезки:
/// нарезка живёт в источниках (2C), и второй её реализации в приложении быть
/// не должно. Отсюда правило: файл, который не помещается в контекст модели,
/// не добавляется, а называется вслух — с советом зарегистрировать папку
/// источником, где нарезка как раз есть.
public enum DroppedFileImport {

    public struct Prepared: Sendable {
        public let documents: [PreparedDocument]
        /// Файлы, из которых не удалось достать текст, и почему.
        public let failed: [(file: String, reason: String)]
        /// Файлы, которые не помещаются в контекст модели целиком.
        public let tooLong: [String]

        public init(
            documents: [PreparedDocument],
            failed: [(file: String, reason: String)],
            tooLong: [String]
        ) {
            self.documents = documents
            self.failed = failed
            self.tooLong = tooLong
        }

        /// Что сказать человеку после подготовки. `nil` — сказать нечего.
        public var problem: String? {
            var parts: [String] = []
            if !tooLong.isEmpty {
                parts.append(String(localized: "не помещаются в контекст модели целиком (\(tooLong.joined(separator: ", "))) — зарегистрируйте папку источником, там текст режется на части"))
            }
            if !failed.isEmpty {
                let list = failed.map { "\($0.file): \($0.reason)" }.joined(separator: "; ")
                parts.append(String(localized: "не прочитались — \(list)"))
            }
            return parts.isEmpty ? nil : parts.joined(separator: ". ")
        }
    }

    /// Достаёт текст из файлов и раскладывает их по трём корзинам.
    ///
    /// Метаданные пишутся те же, что у файлов из источника, — `source_file`
    /// и `file_name`: без них просмотрщик исходника не найдёт файл.
    public static func prepare(
        urls: [URL],
        contextLength: Int?,
        extract: (URL) async throws -> String
    ) async -> Prepared {
        var documents: [PreparedDocument] = []
        var failed: [(file: String, reason: String)] = []
        var tooLong: [String] = []

        for url in urls {
            let name = url.lastPathComponent
            do {
                let text = try await extract(url)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    failed.append((file: name, reason: String(localized: "пустой текст")))
                    continue
                }
                if let contextLength,
                   case .tooLong = ContextBudget.check(text, contextLength: contextLength) {
                    tooLong.append(name)
                    continue
                }
                documents.append(PreparedDocument(
                    id: nil,
                    text: text,
                    metadata: [
                        // Полный путь: у разового добавления папки-источника
                        // нет, и относительный путь не от чего считать.
                        "source_file": .string(url.path),
                        // Путь — как на диске, имя — как задумано.
                        "file_name": .string(FileNameEncoding.repaired(name)),
                        "origin": .string("drop"),
                    ]
                ))
            } catch {
                failed.append((file: name, reason: error.localizedDescription))
            }
        }
        return Prepared(documents: documents, failed: failed, tooLong: tooLong)
    }
}
