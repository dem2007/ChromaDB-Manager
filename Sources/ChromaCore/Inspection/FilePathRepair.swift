import Foundation

/// Приведение путей уже записанных чанков к единой форме.
///
/// Коллекции, наполненные прежними сборками, хранят путь так, как его отдала
/// файловая система: «й» двумя знаками. Для ChromaDB это другая строка, чем
/// та, что набирает человек в фильтре или агент в `get_file`, — и файл,
/// лежащий в коллекции, не находится по собственному пути. Заодно у таких
/// чанков нет поля `file_id`, которым файл просят целиком.
///
/// Только метаданные: текст не меняется, значит и векторы не пересчитываются.
public enum FilePathRepair {
    /// Поля, которые уборка переписывает.
    public static let repairedKeys = ["source_file", "file_id", "file_name"]

    /// Нужна ли чанку уборка.
    ///
    /// Два условия, и второе не менее важно первого: путь уже может быть
    /// в единой форме, а отпечатка всё равно нет — коллекция наполнена до
    /// того, как поле появилось.
    public static func needsRepair(_ metadata: ChromaMetadata?) -> Bool {
        guard let path = filePath(metadata) else { return false }
        if Array(path.utf8) != Array(FilePathKey.canonical(path).utf8) { return true }
        guard case .string(let fingerprint)? = metadata?["file_id"], !fingerprint.isEmpty else { return true }
        return fingerprint != SourceSyncService.fileFingerprint(path)
    }

    /// Что переписать у этих записей. Записи, которым уборка не нужна,
    /// в список не попадают: обновление, ничего не меняющее, — это цена
    /// запроса, уплаченная зря.
    public static func updates(for records: [DocumentRecord]) -> [DocumentUpdate] {
        records.compactMap { record in
            guard needsRepair(record.metadata), let path = filePath(record.metadata) else { return nil }
            let canonical = FilePathKey.canonical(path)
            var fields: ChromaMetadata = [
                "source_file": .string(canonical),
                "file_id": .string(SourceSyncService.fileFingerprint(canonical)),
            ]
            // Имя файла приводится к той же форме — по нему приложение ищет
            // похожие пути, когда агент промахнулся мимо папок.
            if case .string(let name)? = record.metadata?["file_name"], !name.isEmpty {
                fields["file_name"] = .string(FilePathKey.canonical(name))
            }
            return DocumentUpdate(id: record.id, metadata: fields)
        }
    }

    /// Сколько разных файлов стоит за этими записями — то, что видит человек
    /// в отчёте: «двенадцать чанков» ничего не говорит, «три файла» говорит.
    public static func fileCount(of records: [DocumentRecord]) -> Int {
        Set(records.compactMap { filePath($0.metadata).map(FilePathKey.canonical) }).count
    }

    public static func filePath(_ metadata: ChromaMetadata?) -> String? {
        guard case .string(let path)? = metadata?["source_file"], !path.isEmpty else { return nil }
        return path
    }
}
