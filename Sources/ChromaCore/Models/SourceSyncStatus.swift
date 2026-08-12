import Foundation

/// Что карточка источника говорит про его синхронизацию.
///
/// **Зачем отдельным типом.** Строка «ещё не синхронизирован» — утверждение
/// о факте, и оно было неверным: сведения о манифесте подгружаются асинхронно,
/// а словарь, в котором они лежат, до этого просто пуст. Отсутствие ключа
/// означало сразу две разные вещи — «ещё не прочитали» и «прочитали, там
/// пусто», — и обе печатались одинаково. Здесь они разведены, и разведены
/// в ядре, потому что у приложенческого таргета нет тестов, а это ровно то
/// решение, которое надо удержать от повторения.
public enum SourceSyncStatus: Equatable, Sendable {
    /// Манифест ещё не прочитан. Сказать про источник нечего — и «нечего
    /// сказать» это не «не синхронизирован».
    case unknown
    /// Прочитан, и он пуст: источник действительно ни разу не проходил.
    case neverSynced
    /// Прочитан, в нём что-то есть.
    ///
    /// `files` — **все** файлы источника, и текстовые, и таблицы. Раньше здесь
    /// стояло число записей файлового манифеста, и папка из двух файлов
    /// показывала «файлов 1»: таблица уходила другим конвейером и в это число
    /// не попадала. Формально верно, читается неверно.
    case synced(files: Int, chunks: Int, tableRows: Int, updatedAt: Date?)

    /// Записей в коллекции по мнению манифеста: чанки файлов плюс строки
    /// таблиц. Это то самое число, которое видно на вкладке «Коллекции», —
    /// и увидеть его человек должен здесь же, а не складывать в уме.
    public var records: Int {
        guard case .synced(_, let chunks, let rows, _) = self else { return 0 }
        return chunks + rows
    }

    public static func of(
        info: (files: Int, chunks: Int, updatedAt: Date?)?,
        tableRows: Int,
        tableFiles: Int
    ) -> SourceSyncStatus {
        guard let info else {
            // Строк из таблиц может быть известно раньше, чем файловый
            // манифест: это два разных файла и два разных чтения.
            return tableRows > 0
                ? .synced(files: tableFiles, chunks: 0, tableRows: tableRows, updatedAt: nil)
                : .unknown
        }
        guard info.files > 0 || tableRows > 0 else { return .neverSynced }
        return .synced(
            files: info.files + tableFiles, chunks: info.chunks,
            tableRows: tableRows, updatedAt: info.updatedAt
        )
    }

    public var line: String {
        switch self {
        case .unknown:
            return String(localized: "сведения о синхронизации загружаются…")
        case .neverSynced:
            return String(localized: "ещё не синхронизирован")
        case .synced(let files, let chunks, let rows, let updatedAt):
            let filesText = RussianCount.grouped(files, "файл", "файла", "файлов")
            let recordsText = RussianCount.grouped(chunks + rows, "запись", "записи", "записей")
            // Разбивка — только когда есть что разбивать: при одном виде
            // содержимого скобки повторяли бы итог другими словами.
            let breakdown = (chunks > 0 && rows > 0)
                ? String(localized: " (чанков \(chunks.formatted()), строк из таблиц \(rows.formatted()))")
                : ""
            let when = updatedAt.map {
                String(localized: " · обновлён \($0.formatted(date: .abbreviated, time: .shortened))")
            } ?? ""
            return String(localized: "в манифесте: \(filesText) → \(recordsText)\(breakdown)\(when)")
        }
    }

    /// Единственный случай, когда карточка утверждает, что работы не было.
    public var claimsNeverSynced: Bool { self == .neverSynced }
}
