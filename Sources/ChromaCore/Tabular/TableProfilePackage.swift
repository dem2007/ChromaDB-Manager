import Foundation

/// Профили сопоставления в переносимом виде.
///
/// Зачем файл, а не «настройте ещё раз»: профиль — это разметка чужого
/// формата, сделанная руками. Кто-то один разобрался, какая колонка что
/// значит в выгрузке из учётной системы, и это знание должно доезжать до
/// остальных, а не восстанавливаться каждым заново по той же таблице.
///
/// Формат тот же, что у переноса настроек: версия, дата, версия
/// приложения — и данные. Версия первым полем, потому что читать её будут
/// в том числе те сборки, которых ещё нет.
public struct TableProfilePackage: Codable, Hashable, Sendable {
    /// Версия формата файла. Растёт, когда меняется то, что нельзя прочитать
    /// прежним разбором.
    public static let currentVersion = 1

    public var version: Int
    public var exportedAt: Date
    /// Чем выгружено — для разговора «а у меня не открывается».
    public var appVersion: String?
    /// Имя источника, откуда профили взяты. Ни на что не влияет: подсказка
    /// человеку, который через полгода найдёт файл в загрузках.
    public var sourceName: String?
    public var profiles: [TableProfile]

    public init(
        version: Int = TableProfilePackage.currentVersion,
        exportedAt: Date = Date(),
        appVersion: String? = nil,
        sourceName: String? = nil,
        profiles: [TableProfile]
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.sourceName = sourceName
        self.profiles = profiles
    }
}

/// Чтение и запись файла профилей, и слияние прочитанного с тем, что уже есть.
public enum TableProfileTransfer {
    public enum TransferError: LocalizedError, Equatable {
        /// Файл разобрался, но это не профили: JSON бывает какой угодно.
        case notAProfileFile
        /// Файл новее, чем эта сборка умеет читать. Разбирать его «как
        /// получится» нельзя: пропущенное поле — это молча потерянная разметка.
        case tooNew(version: Int)
        case empty

        public var errorDescription: String? {
            switch self {
            case .notAProfileFile:
                return String(localized: "Это не файл профилей сопоставления.")
            case .tooNew(let version):
                return String(localized: "Файл записан версией формата \(version), а эта сборка читает до \(TableProfilePackage.currentVersion). Обновите приложение.")
            case .empty:
                return String(localized: "В файле нет ни одного профиля.")
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .notAProfileFile:
                return String(localized: "Выгрузите профили кнопкой «Экспорт профилей…» — она пишет файл, который эта кнопка читает.")
            case .tooNew, .empty:
                return nil
            }
        }
    }

    public static func encode(_ package: TableProfilePackage) throws -> Data {
        let encoder = JSONEncoder()
        // Читаемый файл: его открывают глазами и правят руками чаще, чем
        // признаются.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(package)
    }

    public static func decode(_ data: Data) throws -> TableProfilePackage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let package = try? decoder.decode(TableProfilePackage.self, from: data) else {
            throw TransferError.notAProfileFile
        }
        guard package.version <= TableProfilePackage.currentVersion else {
            throw TransferError.tooNew(version: package.version)
        }
        guard !package.profiles.isEmpty else { throw TransferError.empty }
        return package
    }

    /// Что сделало слияние — чтобы сказать это человеку, а не «импортировано».
    public struct MergeResult: Hashable, Sendable {
        public var profiles: [TableProfile]
        /// Имена профилей, которых не было.
        public var added: [String]
        /// Имена профилей, которые заменены целиком.
        public var replaced: [String]

        public var isEmpty: Bool { added.isEmpty && replaced.isEmpty }
    }

    /// Слияние по имени: одноимённый профиль заменяется, остальные добавляются.
    ///
    /// **По имени, а не по `id`.** Имя — то, чем профиль называет человек и
    /// по чему он выбирает его в списке; `id` того же профиля на другой машине
    /// всегда другой, и слияние по `id` превращало бы обмен файлами в
    /// накопление одинаковых строк с одинаковыми именами.
    ///
    /// **Идентификатор при замене сохраняется старый** — и это не мелочь:
    /// именно на него ссылаются назначения файлам (`tableProfileAssignments`).
    /// Возьми мы `id` из файла, все назначения указывали бы в пустоту, а на
    /// экране это выглядело бы как «настройки слетели».
    public static func merge(_ incoming: [TableProfile], into existing: [TableProfile]) -> MergeResult {
        var result = existing
        var added: [String] = []
        var replaced: [String] = []

        for profile in incoming {
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if let index = result.firstIndex(where: { $0.name == name }) {
                var updated = profile
                updated.id = result[index].id
                updated.name = name
                result[index] = updated
                replaced.append(name)
            } else {
                var updated = profile
                updated.name = name
                result.append(updated)
                added.append(name)
            }
        }
        return MergeResult(profiles: result, added: added, replaced: replaced)
    }
}
